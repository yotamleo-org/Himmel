const TENANT_HOST = /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.atlassian\.net$/;
const LOOPBACK_HOSTS = new Set(['127.0.0.1', 'localhost', '[::1]']);

/**
 * Returns `raw` when it is an allowed Jira destination, throws otherwise. `allowHost` is the operator's
 * JIRA_ALLOW_HOST value (shell environment or ~/.himmel/himmel.conf), or undefined when none is named.
 */
export function checkJiraDestination(raw, what, allowHost) {
  const refuse = (why) => {
    throw new Error(
      `${what} is refused: ${why}. The Jira destination must be https://<tenant>.atlassian.net. ` +
        'A self-hosted or other Jira host is allowed only when the operator names it in JIRA_ALLOW_HOST ' +
        '(shell environment or ~/.himmel/himmel.conf, never a project file), for example ' +
        'JIRA_ALLOW_HOST=jira.corp.example. No request was sent and no credential left this process.',
    );
  };
  let url;
  try {
    url = new URL(raw);
  } catch {
    return refuse('it is not a valid URL');
  }
  const secure = url.protocol === 'https:';
  if (!secure && url.protocol !== 'http:') return refuse('it is not an https URL');
  if (!url.hostname) return refuse('it has no hostname');
  if (url.username || url.password) return refuse('it carries a user name or password');
  const allowed = (allowHost ?? '').trim().toLowerCase();
  const named = allowed !== '' && url.host === allowed;
  if (named && (secure || (LOOPBACK_HOSTS.has(url.hostname) && url.port !== ''))) return raw;
  if (!secure) return refuse(named ? 'plain http is allowed only for a loopback host named with its port in JIRA_ALLOW_HOST' : 'it is not an https URL');
  if (TENANT_HOST.test(url.hostname) && !url.port) return raw;
  return refuse(allowed ? 'its host is neither a tenant of atlassian.net nor the one JIRA_ALLOW_HOST names' : 'its host is not a tenant of atlassian.net');
}
