import { resolveAccountDeletionRedirectTo } from './account-deletion-url.mjs';

/**
 * Public builds must carry a usable account-deletion return URL. Local and
 * generic CI builds may omit NEXT_PUBLIC_APP_ENV and keep the runtime fail-closed
 * behavior; staging/production builds are checked before Next.js bundles values.
 */
export function validateAccountDeletionBuildConfig({ appEnv, configuredUrl }) {
  const environment = appEnv?.trim().toLowerCase();
  if (environment !== 'staging' && environment !== 'production') {
    return { valid: true, skipped: true };
  }

  const configured = configuredUrl?.trim() ?? '';
  let currentOrigin = '';
  try {
    currentOrigin = new URL(configured).origin;
  } catch {
    // The shared resolver returns null for malformed or missing values.
  }

  const redirectTo = resolveAccountDeletionRedirectTo({
    appEnv: environment,
    configuredUrl: configured,
    nodeEnv: 'production',
    currentOrigin,
  });

  return redirectTo
    ? { valid: true, skipped: false, redirectTo }
    : { valid: false, skipped: false };
}
