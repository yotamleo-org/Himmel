// peer-marker.mjs: the one signer and verifier of the peer-bridge fence marker
//   <<<PEER-UNTRUSTED nonce=<16hex> mac=<16hex>>>>
// where mac is HMAC-SHA256(key, nonce) truncated to 16 hex. The taint hooks run
// it under node; the bridge's read path imports it.
//
// CLI: node peer-marker.mjs verify --key-file <path>   (text on stdin)
//   exit 0 and stdout `verified` when a marker in the text verifies, exit 1 and
//   stdout `unverified` when none does, 2 a usage or key error, 3 the 5 s timer
//   fired. Node exits 1 on an uncaught throw too, so a caller trusts exit 1 only
//   with the `unverified` line. The key comes from a file, never argv.
import { createHmac, timingSafeEqual } from 'node:crypto';
import { readFileSync, realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const MARKER_RE = /<<<PEER-UNTRUSTED nonce=([0-9a-f]{16}) mac=([0-9a-f]{16})>>>/g;

function mac(key, nonce) {
  return createHmac('sha256', key).update(nonce).digest('hex').slice(0, 16);
}

export function signFence(key, nonce) {
  if (!/^[0-9a-f]{16}$/.test(nonce)) throw new Error('nonce must be 16 lowercase hex');
  return `<<<PEER-UNTRUSTED nonce=${nonce} mac=${mac(key, nonce)}>>>`;
}

export function verifyAny(key, text) {
  for (const m of text.matchAll(MARKER_RE)) {
    const want = Buffer.from(mac(key, m[1]), 'utf8');
    const got = Buffer.from(m[2], 'utf8');
    if (timingSafeEqual(want, got)) return true;
  }
  return false;
}

async function main(argv) {
  const timer = setTimeout(() => process.exit(3), 5000);
  timer.unref();
  if (argv[0] !== 'verify' || argv[1] !== '--key-file' || !argv[2] || argv.length !== 3) {
    process.stderr.write('usage: peer-marker.mjs verify --key-file <path> (text on stdin)\n');
    return 2;
  }
  const key = readFileSync(argv[2]);
  if (key.length === 0) {
    process.stderr.write('peer-marker: empty key file\n');
    return 2;
  }
  const chunks = [];
  for await (const c of process.stdin) chunks.push(c);
  const ok = verifyAny(key, Buffer.concat(chunks).toString('utf8'));
  process.stdout.write(ok ? 'verified\n' : 'unverified\n');
  return ok ? 0 : 1;
}

// Real paths on both sides: the plugin dir may be reached through a symlink, and
// node reports the main module's real path in import.meta.url.
function invokedAsScript() {
  try {
    return Boolean(process.argv[1]) && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

if (invokedAsScript()) {
  main(process.argv.slice(2)).then(
    (rc) => process.exit(rc),
    (err) => {
      process.stderr.write(`peer-marker: ${err && err.message}\n`);
      process.exit(2);
    },
  );
}
