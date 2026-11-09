import { describe, it, expect, afterEach, vi } from 'vitest';
import { authHeader, confluenceAuthHeader, projectKey } from './client.js';

// A missing setting names where it lives (the config layer) and the verb that shows it,
// and a missing credential fails before a request is built, never as an empty Basic header and a 401.
describe('settings errors point at the config layer and the verb', () => {
  afterEach(() => vi.unstubAllEnvs());

  it('JIRA_PROJECT_KEY unset: the error names ~/.himmel/himmel.conf and jira config, not .env', () => {
    vi.stubEnv('JIRA_PROJECT_KEY', '');
    expect(() => projectKey()).toThrow(/~\/\.himmel\/himmel\.conf/);
    expect(() => projectKey()).toThrow(/jira config/);
    expect(() => projectKey()).not.toThrow(/your \.env/);
  });

  it('JIRA_EMAIL unset: authHeader fails up front naming the keyring step and the verb', () => {
    vi.stubEnv('JIRA_EMAIL', '');
    vi.stubEnv('JIRA_API_TOKEN', 'tok-value-1');
    expect(() => authHeader()).toThrow(/JIRA_EMAIL is not set/);
    expect(() => authHeader()).toThrow(/himmel-secrets/);
    expect(() => authHeader()).toThrow(/jira config/);
    expect(() => authHeader()).not.toThrow(/tok-value-1/);
  });

  it('JIRA_API_TOKEN unset: authHeader fails up front naming the keyring step and the verb', () => {
    vi.stubEnv('JIRA_EMAIL', 'who@example.invalid');
    vi.stubEnv('JIRA_API_TOKEN', '');
    expect(() => authHeader()).toThrow(/JIRA_API_TOKEN is not set/);
    expect(() => authHeader()).toThrow(/himmel-secrets put --stdin JIRA_API_TOKEN/);
    expect(() => authHeader()).toThrow(/jira config/);
  });

  it('control: both set builds the Basic header', () => {
    vi.stubEnv('JIRA_EMAIL', 'who@example.invalid');
    vi.stubEnv('JIRA_API_TOKEN', 'tok');
    expect(authHeader()).toBe(`Basic ${Buffer.from('who@example.invalid:tok').toString('base64')}`);
  });

  it('control: Confluence creds alone still build a Confluence header with no Jira creds', () => {
    vi.stubEnv('JIRA_EMAIL', '');
    vi.stubEnv('JIRA_API_TOKEN', '');
    vi.stubEnv('CONFLUENCE_EMAIL', 'c@x');
    vi.stubEnv('CONFLUENCE_API_TOKEN', 'ctok');
    expect(confluenceAuthHeader()).toBe(`Basic ${Buffer.from('c@x:ctok').toString('base64')}`);
  });
});
