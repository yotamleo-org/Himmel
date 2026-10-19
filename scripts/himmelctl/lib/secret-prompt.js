'use strict';
// scripts/himmelctl/lib/secret-prompt.js — read ONE secret on a TTY with no
// echo: raw mode, one bullet per key, never written to a readline history.
//
// The wizard's readline (terminal:false) already listens on stdin, so while the
// prompt runs its 'data' listeners are lifted off and put back afterwards: the
// typed bytes must reach neither the terminal nor the wizard's line buffer.
// The label is printed AFTER raw mode is on, so a caller that answers as soon
// as it sees the label can never be echoed.

const BULLET = '•';

// Resolves the typed value ('' when only Enter was pressed). Ctrl-C restores
// the terminal and re-raises SIGINT. A non-TTY input is the caller's job.
function readMasked(label, { input = process.stdin, output = process.stdout } = {}) {
  return new Promise((resolve) => {
    const saved = input.listeners('data');
    input.removeAllListeners('data');
    input.setRawMode(true);
    input.resume();
    output.write(label);
    let value = '';
    const finish = () => {
      input.removeListener('data', onData);
      input.setRawMode(false);
      for (const fn of saved) input.on('data', fn);
      output.write('\n');
    };
    function onData(chunk) {
      const s = chunk.toString('utf8');
      if (s.startsWith('\u001b')) return;
      for (const ch of s) {
        if (ch === '\r' || ch === '\n') { finish(); resolve(value); return; }
        if (ch === '\u0003') { finish(); process.kill(process.pid, 'SIGINT'); resolve(''); return; }
        if (ch === '\u007f' || ch === '\b') {
          if (value.length > 0) { value = Array.from(value).slice(0, -1).join(''); output.write('\b \b'); }
        } else if (ch >= ' ') {
          value += ch;
          output.write(BULLET);
        }
      }
    }
    input.on('data', onData);
  });
}

module.exports = { readMasked, BULLET };
