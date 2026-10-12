const ACCOUNT_DELETION_PATH = '/account-deletion';

/**
 * Resolves the only URL to which the account deletion OTP may return.
 * Local HTTP is accepted only for loopback hosts outside production builds.
 * Staging and production require an explicitly configured public HTTPS URL.
 */
export function resolveAccountDeletionRedirectTo({
  appEnv,
  configuredUrl,
  nodeEnv,
  currentOrigin,
}) {
  const environment = appEnv || (nodeEnv === 'production' ? '' : 'local');
  if (!['local', 'staging', 'production'].includes(environment)) return null;
  if (environment === 'local' && nodeEnv === 'production') return null;

  let origin;
  try {
    origin = new URL(currentOrigin);
  } catch {
    return null;
  }
  if (origin.origin !== currentOrigin || origin.username || origin.password) return null;

  let candidate;
  const configured = configuredUrl?.trim() ?? '';
  if (configured) {
    try {
      candidate = new URL(configured);
    } catch {
      return null;
    }
  } else if (environment === 'local') {
    candidate = new URL(ACCOUNT_DELETION_PATH, origin.origin);
  } else {
    return null;
  }

  if (
    candidate.username ||
    candidate.password ||
    candidate.pathname !== ACCOUNT_DELETION_PATH ||
    candidate.search ||
    candidate.hash ||
    candidate.origin !== origin.origin
  ) {
    return null;
  }

  if (candidate.protocol === 'https:') {
    if (environment !== 'local' && !isPublicHost(candidate.hostname)) return null;
    return candidate.toString();
  }

  if (
    environment === 'local' &&
    nodeEnv !== 'production' &&
    candidate.protocol === 'http:' &&
    isLoopbackHost(candidate.hostname)
  ) {
    return candidate.toString();
  }
  return null;
}

function isLoopbackHost(hostname) {
  const host = hostname.toLowerCase().replace(/^\[|\]$/g, '');
  return host === 'localhost' || host === '127.0.0.1' || host === '::1';
}

function isPublicHost(hostname) {
  const host = hostname.toLowerCase().replace(/\.$/, '');
  if (
    !host.includes('.') ||
    host === 'example.com' ||
    host === 'example.net' ||
    host === 'example.org' ||
    host.endsWith('.example.com') ||
    host.endsWith('.example.net') ||
    host.endsWith('.example.org') ||
    host === 'localhost' ||
    host.endsWith('.localhost') ||
    host.endsWith('.local') ||
    host.endsWith('.internal') ||
    host.endsWith('.example') ||
    host.endsWith('.invalid') ||
    host.endsWith('.test') ||
    /^\d{1,3}(\.\d{1,3}){3}$/.test(host) ||
    host.includes(':')
  ) {
    return false;
  }
  return true;
}
