import { afterEach, describe, expect, it, vi } from 'vitest';
import { mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { ancestorValue, hostNsFile, walk, MAX_HOPS } from './fence-ancestry.js';

vi.unmock('./fence-ancestry.js');

const HOST = 'pid:[4026531836] user:[4026531837]';
const SANDBOX = 'pid:[4026532999] user:[4026532998]';

interface P { pid: number; ppid?: number; uid?: number; env?: Record<string, string> | null; status?: string | null; nspid?: string; name?: string }

function fakeProc(procs: P[], o: { ns?: string; ref?: string | null } = {}) {
  const procRoot = mkdtempSync(join(tmpdir(), 'fence-proc-'));
  for (const p of procs) {
    const d = join(procRoot, String(p.pid));
    mkdirSync(d);
    const uid = p.uid ?? 1000;
    const status = p.status !== undefined ? p.status
      : `Name:\t${p.name ?? 'proc'}\nPid:\t${p.pid}\nPPid:\t${p.ppid ?? 0}\nUid:\t${uid}\t${uid}\t${uid}\t${uid}\nNSpid:\t${p.nspid ?? p.pid}\n`;
    if (status !== null) writeFileSync(join(d, 'status'), status);
    if (p.env !== null) writeFileSync(join(d, 'environ'), Object.entries(p.env ?? { PATH: '/usr/bin' }).map(([k, v]) => `${k}=${v}\0`).join(''));
  }
  const [pidNs, userNs] = (o.ns ?? HOST).split(' ');
  mkdirSync(join(procRoot, String(procs[0].pid), 'ns'));
  symlinkSync(pidNs, join(procRoot, String(procs[0].pid), 'ns', 'pid'));
  symlinkSync(userNs, join(procRoot, String(procs[0].pid), 'ns', 'user'));
  symlinkSync(String(procs[0].pid), join(procRoot, 'self'));
  const hostNsPath = join(procRoot, 'host-ns-ref');
  if (o.ref !== null) writeFileSync(hostNsPath, `${o.ref ?? HOST}\n`);
  return { procRoot, hostNsPath };
}

const chain = (over: Partial<Record<300 | 200 | 100 | 1, Partial<P>>> = {}): P[] => [
  { pid: 300, ppid: 200, ...over[300] },
  { pid: 200, ppid: 100, ...over[200] },
  { pid: 100, ppid: 1, ...over[100] },
  { pid: 1, ppid: 0, uid: 0, env: null, ...over[1] },
];

const passwdHome = () => execFileSync('getent', ['passwd', String(process.getuid?.())], { encoding: 'utf8' }).split(':')[5];

afterEach(() => vi.unstubAllEnvs());

describe('walk: the one allow', () => {
  it('T1b: a marked grandparent with a clean ctx.env refuses; with the marker removed, equal ids and a clean tree, it allows', () => {
    const marked = walk(fakeProc(chain({ 100: { env: { HIMMEL_BRIDGE_SESSION: '1' } } })));
    expect(marked).toMatchObject({ stop: 'refuse', marker: 'HIMMEL_BRIDGE_SESSION', farthest: 100 });
    expect(marked.why).toMatch(/HIMMEL_BRIDGE_SESSION=1 in the start-up env of ancestor 100/);
    expect(walk(fakeProc(chain()))).toEqual({ marker: null, stop: 'allow' });
  });

  it('each of the three markers refuses, and a value other than 1 does not', () => {
    for (const m of ['HIMMEL_CONSOLE_LEG', 'HIMMEL_RELEASE_MANAGER', 'HIMMEL_BRIDGE_SESSION']) {
      expect(walk(fakeProc(chain({ 200: { env: { [m]: '1' } } }))).marker).toBe(m);
    }
    expect(walk(fakeProc(chain({ 200: { env: { HIMMEL_BRIDGE_SESSION: '0' } } }))).stop).toBe('allow');
  });

  it('the walker\'s own start-up env counts', () => {
    expect(walk(fakeProc(chain({ 300: { env: { HIMMEL_CONSOLE_LEG: '1' } } }))).marker).toBe('HIMMEL_CONSOLE_LEG');
  });

  it('no /proc at all (macOS) leaves the env check alone', () => {
    expect(walk({ procRoot: join(tmpdir(), 'no-such-proc-9849') })).toMatchObject({ stop: 'allow', marker: null });
  });
});

describe('walk: T1c, every other stop refuses with its own reason', () => {
  const refuses = (procs: P[], why: RegExp) => {
    const r = walk(fakeProc(procs));
    expect(r.stop).toBe('refuse');
    expect(r.why).toMatch(why);
  };

  it('an unreadable same-uid parent', () => refuses(chain({ 200: { env: null } }), /start-up env of ancestor 200 cannot be read/));

  it('(a) one unreadable environ on the same-uid hop directly below pid 1 is tolerated', () => {
    expect(walk(fakeProc(chain({ 100: { env: null } })))).toEqual({ marker: null, stop: 'allow' });
  });
  it('(b) an unreadable environ at a middle hop refuses', () => refuses(chain({ 200: { env: null } }), /start-up env of ancestor 200 cannot be read/));
  it('(c) two unreadable hops refuse', () => refuses(chain({ 200: { env: null }, 100: { env: null } }), /start-up env of ancestor 200 cannot be read/));
  it('(d) a different-uid hop at PPid 1 refuses', () => refuses(chain({ 100: { uid: 0, env: null } }), /ancestor 100 runs as another uid/));
  it('the tolerated hop must show one NSpid field', () => refuses(chain({ 100: { env: null, nspid: '100 7' } }), /start-up env of ancestor 100 cannot be read/));
  it('a parent of another uid that is not pid 1 (sudo)', () => refuses(chain({ 200: { uid: 0 } }), /ancestor 200 runs as another uid.*tmux or systemd-run --user/));
  it(`${MAX_HOPS} hops`, () => {
    const long: P[] = Array.from({ length: MAX_HOPS + 2 }, (_, i) => ({ pid: 1000 + i, ppid: 1001 + i }));
    refuses([...long, { pid: 1, ppid: 0, uid: 0, env: null }], new RegExp(`${MAX_HOPS} hops without reaching pid 1`));
  });
  it('a status with no PPid:', () => refuses(chain({ 200: { status: 'Name:\tsh\nUid:\t1000\t1000\t1000\t1000\n' } }), /process 200 has no parseable PPid:/));
  it('a process gone mid-walk', () => refuses(chain({ 200: { ppid: 150 } }), /process 150 cannot be read/));
  it('an ancestry that ends short of pid 1', () => refuses(chain({ 100: { ppid: 0 } }), /ends at 100, not at pid 1/));

  it('a comm with spaces and ) does not confuse the parse: the walk reads status, not stat', () => {
    const t = fakeProc(chain({ 200: { name: 'evil) S 1 (x' } }));
    writeFileSync(join(t.procRoot, '200', 'stat'), '200 (evil) S 1 (x) S 1 200 200 0');
    expect(walk(t).stop).toBe('allow');
  });
});

describe('walk: T1d, a namespace root', () => {
  it('a same-uid pid 1 with a multi-field NSpid: refuses, with or without a marker there', () => {
    for (const env of [null, { HIMMEL_BRIDGE_SESSION: '1' }]) {
      const r = walk(fakeProc(chain({ 1: { uid: 1000, nspid: '1 4242', env } })));
      expect(r.stop).toBe('refuse');
      expect(r.why).toMatch(env ? /HIMMEL_BRIDGE_SESSION=1 in the start-up env of ancestor 1.*root of a pid namespace/ : /pid 1 is the root of a pid namespace/);
    }
  });

  it('ancestorValue reads the farthest marked ancestor, not a nearer one', () => {
    const t = fakeProc(chain({
      200: { env: { HIMMEL_BRIDGE_SESSION: '1', HIMMEL_BRIDGE_CHAT: '666' } },
      100: { env: { HIMMEL_BRIDGE_SESSION: '1', HIMMEL_BRIDGE_CHAT: '42' } },
    }));
    expect(ancestorValue('HIMMEL_BRIDGE_CHAT', t)).toBe('42');
    expect(ancestorValue('HIMMEL_BRIDGE_CHAT', fakeProc(chain()))).toBeNull();
  });
});

describe('walk: T1e, the host reference', () => {
  it('a pid 1 of a foreign Uid: and one NSpid: field, with own ids unlike host-ns, refuses; with the comparison removed it allows', () => {
    const t = fakeProc(chain(), { ns: SANDBOX });
    const r = walk(t);
    expect(r.stop).toBe('refuse');
    expect(r.why).toMatch(/runs in other namespaces .*than the host reference/);
    expect(walk({ ...t, disable: ['ns'] }).stop).toBe('allow');
  });

  it('a missing or malformed host-ns refuses with the remedy', () => {
    expect(walk(fakeProc(chain(), { ref: null })).why).toMatch(/host-ns is missing.*restart the bridge, or run `bun scripts\/telegram\/poller.ts --write-host-ns`/);
    expect(walk(fakeProc(chain(), { ref: 'pid:[1]' })).why).toMatch(/host-ns is malformed; restart the bridge/);
  });

  it('forged BRIDGE_ROOT or HOME holding the walker\'s ids refuse against the fixed-path reference; an env-resolved reference would allow', () => {
    const t = fakeProc(chain(), { ns: SANDBOX });
    const fixed = hostNsFile();
    for (const name of ['BRIDGE_ROOT', 'HOME']) {
      const scratch = mkdtempSync(join(tmpdir(), `forged-${name}-`));
      const forged = name === 'HOME' ? join(scratch, '.claude', 'handover', 'bridge') : scratch;
      mkdirSync(forged, { recursive: true });
      writeFileSync(join(forged, 'host-ns'), `${SANDBOX}\n`);
      vi.stubEnv(name, scratch);
      expect(hostNsFile()).toBe(fixed);
      expect(walk(t).stop).toBe('refuse');
      expect(walk({ ...t, hostNsPath: join(forged, 'host-ns') }).stop).toBe('allow');
      vi.unstubAllEnvs();
    }
  });

  it('hostNsFile() is the passwd home\'s fixed path, whatever BRIDGE_ROOT and HOME say', () => {
    vi.stubEnv('HOME', mkdtempSync(join(tmpdir(), 'home-')));
    vi.stubEnv('BRIDGE_ROOT', mkdtempSync(join(tmpdir(), 'bridge-')));
    expect(hostNsFile()).toBe(join(passwdHome(), '.claude', 'handover', 'bridge', 'host-ns'));
  });
});
