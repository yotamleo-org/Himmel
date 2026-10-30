'use strict';
// scripts/himmelctl/lib/profile-lock.js — the one lock every writer of the
// saved install profile takes: bin.js writeCache() and the
// retired-cadence rewrite (dropRetiredFromProfileFile). The config UI save
// reaches the profile through himmelctl, so it takes this lock without a file
// edit. The lock is a file beside the profile, created exclusively and holding
// the owner's pid.

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const WAIT_MS = 10000;
const POLL_MS = 20;
// A lock whose owner is gone is taken over; this age only covers an owner we
// cannot signal (another user's pid).
const STALE_MS = 60000;

function sleep(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

// The owner text of a lock that is stale (owner gone), else null.
function staleOwner(lock) {
  let text;
  try {
    text = fs.readFileSync(lock, 'utf8');
  } catch (_e) {
    return null; // released, or not written yet — try again
  }
  const pid = parseInt(text, 10);
  if (Number.isInteger(pid) && pid > 0) {
    try {
      process.kill(pid, 0);
      return null; // a live owner keeps the lock however long it holds it
    } catch (e) {
      if (e.code === 'ESRCH') return text;
    }
  }
  try {
    return Date.now() - fs.statSync(lock).mtimeMs > STALE_MS ? text : null;
  } catch (_e) {
    return null;
  }
}

// Take a stale lock over by renaming it to a tombstone only this waiter owns.
// Only the waiter whose rename succeeds may retry the create; a peer that lost
// the rename sees ENOENT and goes back to waiting. The renamed file is read
// again: if it is no longer the owner `stale` read, a fresh owner slipped in
// between the read and the rename, so its lock is linked back untouched.
// ponytail: between that rename and the link a third waiter can create the
// lock, leaving two owners; needs a crashed owner and three simultaneous
// waiters, upgrade path is a kernel lock (flock) instead of a lock file.
function takeOver(lock, stale) {
  const tomb = `${lock}.stale.${process.pid}.${crypto.randomBytes(4).toString('hex')}`;
  try {
    fs.renameSync(lock, tomb);
  } catch (_e) {
    return false;
  }
  let moved = null;
  try { moved = fs.readFileSync(tomb, 'utf8'); } catch (_e) { /* unreadable: treated as a fresh owner */ }
  if (moved !== stale) {
    try { fs.linkSync(tomb, lock); } catch (_e) { /* recreated meanwhile: see the ponytail above */ }
  }
  try { fs.unlinkSync(tomb); } catch (_e) { /* already gone */ }
  return moved === stale;
}

function ownerOf(file) {
  try { return fs.readFileSync(file, 'utf8'); } catch (_e) { return null; }
}

// Release our own lock. A waiter that found it stale may have renamed it to a
// tombstone before we got here; it links the lock back once it has seen it is
// ours, so we wait for that and release the restored file too, else a live
// process would keep a lock it already left.
function release(lock) {
  const own = String(process.pid);
  const drop = () => {
    if (ownerOf(lock) !== own) return false;
    try { fs.unlinkSync(lock); } catch (_e) { /* already gone */ }
    return true;
  };
  const prefix = `${path.basename(lock)}.stale.`;
  const inFlight = () => {
    try {
      const dir = path.dirname(lock);
      return fs.readdirSync(dir).some((n) => n.startsWith(prefix) && ownerOf(path.join(dir, n)) === own);
    } catch (_e) {
      return false;
    }
  };
  const deadline = Date.now() + WAIT_MS;
  while (!drop()) {
    // the tombstone goes only after the link-back, so one more look after it
    // is gone sees the restored lock
    if (!inFlight()) { drop(); return; }
    if (Date.now() > deadline) return;
    sleep(5);
  }
}

// Run fn() holding the lock for `profilePath`. Throws if the lock is not free
// within WAIT_MS, so a save fails loud rather than racing an unlocked write.
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
      const stale = staleOwner(lock);
      if (stale !== null && takeOver(lock, stale)) continue;
      if (Date.now() > deadline) throw new Error(`the profile lock ${lock} is held by another himmelctl`);
      sleep(POLL_MS);
    }
  }
  try {
    fs.writeSync(fd, String(process.pid));
    fs.closeSync(fd);
    return fn();
  } finally {
    release(lock);
  }
}

module.exports = { withProfileLock };
