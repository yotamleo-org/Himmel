// scripts/ci/node-suite-reporter.mjs — a node:test reporter that writes one JSON
// line per test:pass or test:fail event, for scripts/ci/js-suite-manifest.mjs:
//   {"file","name","nesting","fail","skip","todo","kind"}
// It runs inside the CI test step, so it never throws: an event it cannot read
// writes nothing, and a reporter bug means fewer manifest lines, never a red step.
//
//   node --test --test-reporter=./scripts/ci/node-suite-reporter.mjs \
//        --test-reporter-destination=<file> \
//        --test-reporter=spec --test-reporter-destination=stdout <globs>

function line(event) {
  try {
    if (!event || (event.type !== 'test:pass' && event.type !== 'test:fail')) return '';
    const d = event.data;
    if (!d || typeof d.file !== 'string') return '';
    return JSON.stringify({
      file: d.file,
      name: typeof d.name === 'string' ? d.name : '',
      nesting: Number.isInteger(d.nesting) ? d.nesting : 0,
      fail: event.type === 'test:fail',
      skip: d.skip !== undefined && d.skip !== false,
      todo: d.todo !== undefined && d.todo !== false,
      kind: d.details && typeof d.details.type === 'string' ? d.details.type : '',
    }) + '\n';
  } catch {
    return '';
  }
}

export default async function* nodeSuiteReporter(source) {
  try {
    for await (const event of source) {
      const out = line(event);
      if (out) yield out;
    }
  } catch {
    // A broken event stream ends the report; the lines already written stand.
  }
}
