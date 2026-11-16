export function diagnostic(error) {
  if (error?.code === 'ETIMEDOUT' || error?.code === 'DEADLINE') return 'read deadline exhausted; retry when the source is available';
  if (error?.code === 'BUDGET') return 'collection request budget exhausted; remaining identities unknown';
  if (error?.httpStatus) return `HTTP ${Number(error.httpStatus)}; check source access and unresolved identities`;
  if (error?.status != null || error?.stderr != null) return 'source subprocess failed; check authentication, access and connectivity';
  return String(error?.message ?? error ?? 'unknown source failure')
    .replace(/Command failed:[\s\S]*/i, 'source subprocess failed; check authentication, access and connectivity')
    .replace(/\b(?:token|authorization|api[_-]?key|password|secret)\s*[:=]\s*\S+/gi, '[redacted]')
    .replace(/https?:\/\/\S+/gi, '[source URL]')
    .replace(/[\x00-\x1f\x7f]+/g, ' ').slice(0, 160);
}

export class Diagnostics {
  errors = [];
  error_count = 0;
  add(error, count = 1) {
    this.error_count += count;
    const text = diagnostic(error);
    if (this.errors.length < 8 && !this.errors.includes(text)) this.errors.push(text);
  }
  merge(result) {
    const errors = Array.isArray(result.errors) ? result.errors : [];
    for (const error of errors) this.add(error);
    if (result.error_count !== undefined && (!Number.isSafeInteger(result.error_count) || result.error_count < errors.length)) {
      this.add('source diagnostic count unreadable');
    } else this.error_count += (result.error_count ?? errors.length) - errors.length;
  }
}
