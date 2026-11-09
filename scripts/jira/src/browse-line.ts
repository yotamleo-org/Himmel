import { baseUrl } from './client.js';

export function browseLine(key: string): string | undefined {
  try {
    return `browse: ${baseUrl()}/browse/${key}`;
  } catch {
    return undefined;
  }
}
