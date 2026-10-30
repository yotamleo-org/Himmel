import envPaths from 'env-paths';
import { join } from 'node:path';

const paths = envPaths('himmel-cli', { suffix: '' });

// On Linux/macOS, paths.cache is already the bare "himmel-cli" dir.
const CACHE_ROOT = paths.cache;

export function cacheRoot(): string {
  return CACHE_ROOT;
}

export function tagDir(tag: string): string {
  return join(cacheRoot(), tag);
}

export function logPath(tag: string): string {
  return join(tagDir(tag), 'normal.log');
}

export function errPath(tag: string): string {
  return join(tagDir(tag), 'error.log');
}

export function indexDir(tag: string): string {
  return join(tagDir(tag), 'index');
}

export function indexEntryPath(tag: string, runId: string): string {
  return join(indexDir(tag), `${runId}.json`);
}

export function lockPath(tag: string): string {
  return join(tagDir(tag), '.lock');
}

export function repoContextPath(tag: string): string {
  return join(tagDir(tag), 'repo-context.json');
}
