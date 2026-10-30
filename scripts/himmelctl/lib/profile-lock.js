'use strict';
// scripts/himmelctl/lib/profile-lock.js — the one lock every writer of the
// saved install profile takes: bin.js writeCache() and the
// retired-cadence rewrite (dropRetiredFromProfileFile). The config UI save
// reaches the profile through himmelctl, so it takes this lock without a file
// edit. The lock is a file beside the profile, created exclusively and holding
// the owner's pid.

const fs = require('fs');
const path = require('path');

const WAIT_MS = 10000;
const POLL_MS = 20;
// A lock whose owner is gone is taken over; this age only covers an owner we
// cannot signal (another user, or a reused pid).
const STALE_MS = 60000;

function sleep(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function ownerGone(lock) {
  let pid;
  try {
    pid = parseInt(fs.readFileSync(lock, 'utf8'), 10);
  } catch (_e) {
    return false; // released, or not written yet — try again
  }
  if (Number.isInteger(pid) && pid > 0) {
    try {
      process.kill(pid, 0);
    } catch (e) {
      if (e.code === 'ESRCH') return true;
    }
  }
  try {
    return Date.now() - fs.statSync(lock).mtimeMs > STALE_MS;
  } catch (_e) {
    return false;
  }
}

// Run fn() holding the lock for `profilePath`. Throws if the lock is not free
// within WAIT_MS, so a save fails loud rather than racing an unlocked write.
// ponytail: two waiters that both find a dead owner can each remove the lock
// and one then removes the other's fresh one; that needs a crashed owner AND
// two simultaneous waiters, upgrade path is an atomic rename-based takeover.
function withProfileLock(profilePath, fn) {
  const lock = `${path.resolve(profilePath)}.lock`;
  const deadline = Date.now() + WAIT_MS;
  let fd;
  for (;;) {
    try {
      fd = fs.openSync(lock, 'wx');
      break;
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
      if (ownerGone(lock)) {
        try { fs.unlinkSync(lock); } catch (_e) { /* a peer took it over */ }
        continue;
      }
      if (Date.now() > deadline) throw new Error(`the profile lock ${lock} is held by another himmelctl`);
      sleep(POLL_MS);
    }
  }
  try {
    fs.writeSync(fd, String(process.pid));
    fs.closeSync(fd);
    return fn();
  } finally {
    try { fs.unlinkSync(lock); } catch (_e) { /* already gone */ }
  }
}

module.exports = { withProfileLock };
