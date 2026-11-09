import { baseUrl } from './client.js';

// The `browse:` line a write read-back prints under its result, so no one reads a secrets file or the
// Jira MCP for the site URL. An unset site URL gives no line: the write has already failed loud then.
export function browseLine(key: string): string | undefined {
  try {
    return `browse: ${baseUrl()}/browse/${key}`;
  } catch {
    return undefined;
  }
}
